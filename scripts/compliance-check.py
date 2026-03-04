#!/usr/bin/env python3
"""
JFrog Runtime Compliance Validator
====================================
Traces a running container image from a Kubernetes cluster back to its source
git commit, validating the full chain of custody via:
  - JFrog Runtime   (running image + digest)
  - Artifactory     (artifact storage + checksums)
  - Build Info      (CI/CD build provenance + git metadata)
  - Evidence        (SLSA / sigstore attestations)

Usage:
  python3 compliance-check.py [--image IMAGE_NAME] [--cluster CLUSTER_NAME]

Environment variables (all optional, defaults shown):
  JF_URL          JFrog platform base URL    (https://danielw.jfrog.io)
  JF_TOKEN_FILE   Path to access token file  (access-token.txt)
  CLUSTER_NAME    Kubernetes cluster name     (tomj-lab-cluster)
  IMAGE_NAME      Container image name        (insecure-demo-app)
  BUILD_NAME      Artifactory build name      (insecure-demo-app-build)
  PROJECT_KEY     Artifactory project key     (runtimedemo)

Exit codes:
  0  All checks passed — image is compliant
  1  One or more checks failed — image is non-compliant
  2  Script error (auth failure, image not found, etc.)
"""

import argparse
import os
import sys
from datetime import datetime, timezone

try:
    import requests
except ImportError:
    print("ERROR: 'requests' library not found. Install with: pip install requests")
    sys.exit(2)


# ── Defaults (override via environment variables) ──────────────────────────────

DEFAULTS = {
    "jf_url":       os.getenv("JF_URL",        "https://danielw.jfrog.io"),
    "token_file":   os.getenv("JF_TOKEN_FILE", "access-token.txt"),
    "cluster":      os.getenv("CLUSTER_NAME",  "tomj-lab-cluster"),
    "image":        os.getenv("IMAGE_NAME",    "insecure-demo-app"),
    "build_name":   os.getenv("BUILD_NAME",    "insecure-demo-app-build"),
    "project_key":  os.getenv("PROJECT_KEY",   "runtimedemo"),
}


# ── Formatting helpers ─────────────────────────────────────────────────────────

WIDTH = 70

def header(step_id, title):
    print(f"\n{'─' * WIDTH}")
    print(f"  Step {step_id}: {title}")
    print(f"{'─' * WIDTH}")

def info(label, value):
    print(f"  {'→':2} {label}: {value}")

def ok(label, value=""):
    suffix = f"  ({value})" if value else ""
    print(f"  {'✅':2} {label}{suffix}")

def warn(label, value=""):
    suffix = f"  ({value})" if value else ""
    print(f"  {'⚠️ ':2} {label}{suffix}")

def fail(label, value=""):
    suffix = f"  ({value})" if value else ""
    print(f"  {'❌':2} {label}{suffix}")

def abort(msg):
    print(f"\n  FATAL: {msg}")
    sys.exit(2)


# ── API helpers ────────────────────────────────────────────────────────────────

def load_token(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        abort(f"Token file not found: {path}")

def parse_dt(s):
    """Parse ISO 8601 datetime string to an aware datetime object."""
    s = s.replace("+0000", "+00:00").replace("Z", "+00:00")
    return datetime.fromisoformat(s)


# ── Validation steps ───────────────────────────────────────────────────────────

def step1_list_clusters(session, base_url, cluster_name):
    header(1, "Enumerate Runtime Clusters")
    r = session.post(f"{base_url}/runtime/api/v1/clusters", json={"limit": 50})
    r.raise_for_status()
    clusters = r.json().get("clusters", [])
    running = [c for c in clusters if c.get("status") == "running"]
    info(f"Clusters found", f"{len(clusters)} total, {len(running)} running")

    target = next((c for c in clusters if c.get("name") == cluster_name), None)
    if not target:
        abort(f"Cluster '{cluster_name}' not found in Runtime")
    if target.get("status") != "running":
        warn(f"Cluster '{cluster_name}' is not running", target.get("status"))
    else:
        ok(f"Cluster '{cluster_name}' is running")

    return target


def step2_find_image(session, base_url, cluster_name, image_name):
    header(2, f"Find Running Image: {image_name}")
    r = session.post(
        f"{base_url}/runtime/api/v1/images/tags",
        json={
            "limit": 50,
            "filters": {
                "cluster_names": [cluster_name],
                "image_names":   [image_name],
            },
        },
    )
    r.raise_for_status()
    tags = [
        t for t in r.json().get("image_tags", [])
        if t.get("name") == image_name and t.get("runtime_status") == "running"
    ]
    if not tags:
        abort(f"No running instance of '{image_name}' found in cluster '{cluster_name}'")

    image = tags[0]
    image_digest  = image["image_digest"]
    image_tag     = image["tag"]
    repo_path     = image["repository_path"]
    risks         = image.get("risks", [])
    workloads     = image.get("workloads", [])
    vulns         = image.get("vulnerabilities", [])

    info("Tag",             image_tag)
    info("Image digest",    image_digest)
    info("Repository path", repo_path)
    info("Workloads",       ", ".join(
        f"{w['cluster']}/{w['namespace']}/{w['name']}" for w in workloads
    ))
    if risks:
        warn("Risks detected", ", ".join(risks))
    else:
        ok("No runtime risks flagged")

    critical_applicable = [
        v for v in vulns
        if v.get("severity") == "Critical" and v.get("applicability") == "applicable"
    ]
    if critical_applicable:
        warn(f"Critical applicable CVEs", str(len(critical_applicable)))
        for v in critical_applicable:
            comp = v["components"][0]["id"] if v.get("components") else "unknown"
            print(f"       • {v['cve_id']} — {comp}")

    return image_digest, image_tag, repo_path, risks, vulns


def step3a_aql_manifest(session, base_url, image_name, image_digest, repo_path):
    header("3a", "Locate Image Manifest in Artifactory (AQL)")
    aql = (
        f'items.find({{'
        f'"repo":{{"$match":"{repo_path}*"}},'
        f'"path":{{"$match":"{image_name}/sha256:{image_digest}"}},'
        f'"name":"manifest.json"'
        f'}}).include("repo","path","name","sha256","created")'
    )
    r = session.post(
        f"{base_url}/artifactory/api/search/aql",
        data=aql,
        headers={"Content-Type": "text/plain"},
    )
    r.raise_for_status()
    results = r.json().get("results", [])
    if not results:
        abort(f"Manifest not found in Artifactory for digest sha256:{image_digest}")

    m = results[0]
    repo_key     = m["repo"]
    manifest_path = m["path"]
    aql_sha256   = m["sha256"]
    created_at   = m["created"]

    info("Repo key",       repo_key)
    info("Manifest path",  manifest_path)
    info("Created at",     created_at)

    if aql_sha256 == image_digest:
        ok("AQL manifest sha256 matches runtime digest")
    else:
        fail("AQL manifest sha256 MISMATCH", f"{aql_sha256} != {image_digest}")

    return repo_key, manifest_path, created_at, aql_sha256 == image_digest


def step3b_storage_checksums(session, base_url, repo_key, manifest_path, image_digest):
    header("3b", "Verify Artifact Checksums (Artifactory Storage API)")
    storage_url = f"{base_url}/artifactory/api/storage/{repo_key}/{manifest_path}/manifest.json"
    r = session.get(storage_url)
    r.raise_for_status()
    data = r.json()

    checksums_sha256 = data.get("checksums", {}).get("sha256", "")
    created_by       = data.get("createdBy", "unknown")

    info("Created by", created_by)

    if checksums_sha256 == image_digest:
        ok("Artifactory checksums.sha256 matches runtime digest")
    else:
        fail("Checksums MISMATCH", f"{checksums_sha256} != {image_digest}")

    return checksums_sha256, checksums_sha256 == image_digest


def step4a_list_builds(session, base_url, project_key, build_name):
    header("4a", f"List Builds in Project '{project_key}'")
    r = session.get(f"{base_url}/artifactory/api/build", params={"project": project_key})
    r.raise_for_status()
    builds = r.json().get("builds", [])
    build_names = [b.get("uri", "").strip("/") for b in builds]
    info("Builds found", ", ".join(build_names) if build_names else "none")

    if build_name not in build_names:
        abort(f"Build '{build_name}' not found in project '{project_key}'")
    ok(f"Target build '{build_name}' found")
    return build_names


def step4b_find_build_run(session, base_url, build_name, project_key, artifact_created_at):
    header("4b", f"Find Matching Build Run for '{build_name}'")
    r = session.get(
        f"{base_url}/artifactory/api/build/{build_name}",
        params={"project": project_key},
    )
    r.raise_for_status()
    runs = r.json().get("buildsNumbers", [])
    info("Build runs found", len(runs))

    artifact_dt = parse_dt(artifact_created_at)

    best_run, best_delta = None, None
    for run in runs:
        run_num  = run.get("uri", "").strip("/")
        started  = run.get("started", "")
        if not started:
            continue
        try:
            run_dt = parse_dt(started)
        except ValueError:
            continue
        delta = abs((run_dt - artifact_dt).total_seconds())
        if best_delta is None or delta < best_delta:
            best_delta = delta
            best_run = (run_num, started, run_dt)

    if not best_run:
        abort("No build run with a parseable start timestamp found")

    build_number, build_started, _ = best_run
    ok(f"Matched build run #{build_number}", f"started {build_started}, Δ{round(best_delta)}s from artifact creation")
    return build_number


def step4c_get_build_info(session, base_url, build_name, build_number, project_key, image_digest):
    header("4c", f"Get Full Build Info (#{build_number})")
    r = session.get(
        f"{base_url}/artifactory/api/build/{build_name}/{build_number}",
        params={"project": project_key},
    )
    r.raise_for_status()
    build_info = r.json().get("buildInfo", {})

    build_url  = build_info.get("url", "")
    vcs_list   = build_info.get("vcs", [])
    git_commit  = vcs_list[0].get("revision")  if vcs_list else None
    git_branch  = vcs_list[0].get("branch")    if vcs_list else None
    git_message = vcs_list[0].get("message")   if vcs_list else None
    git_url     = vcs_list[0].get("url")       if vcs_list else None
    agent       = build_info.get("agent", {})
    principal   = build_info.get("artifactoryPrincipal", "unknown")

    # Check image digest appears in build artifacts
    digest_in_artifacts = any(
        artifact.get("sha256") == image_digest
        for module in build_info.get("modules", [])
        for artifact in module.get("artifacts", [])
    )

    info("CI/CD run",    build_url)
    info("Build agent",  f"{agent.get('name', '?')} v{agent.get('version', '?')}")
    info("Published by", principal)

    if git_commit:
        ok("buildInfo.vcs populated")
        info("Git commit",  git_commit)
        info("Git branch",  git_branch)
        info("Commit msg",  git_message)
        info("Repo URL",    git_url)
    else:
        warn("buildInfo.vcs not populated — git commit not in build info")

    if digest_in_artifacts:
        ok("Image digest found in build artifacts")
    else:
        fail("Image digest NOT found in build artifacts")

    return build_url, git_commit, git_branch, git_message, digest_in_artifacts


def step5a_search_evidence(session, base_url, repo_key, image_name, image_tag):
    header("5a", "Search Evidence Attestations")
    # Evidence is attached to the tag-based list manifest, not the digest-based manifest
    evidence_path = f"{image_name}/{image_tag}/list.manifest.json"
    r = session.get(
        f"{base_url}/evidence/api/v1/evidence-search",
        params={
            "repository_key": repo_key,
            "path":           evidence_path,
        },
    )
    r.raise_for_status()
    evidence_list = r.json().get("evidence", [])

    if not evidence_list:
        warn("No evidence found for this image tag")
        return []

    info("Evidence records found", len(evidence_list))
    for ev in evidence_list:
        verified_icon = "✅" if ev.get("verified") else "❌"
        print(
            f"    {verified_icon} [{ev.get('predicate_slug', '?')}]  "
            f"verified={ev.get('verified')}  "
            f"provider={ev.get('provider_id', '?')}  "
            f"created={ev.get('created_at', '?')}"
        )

    return evidence_list


def step5b_get_evidence_by_id(session, base_url, evidence_list):
    header("5b", "Get Evidence by ID")
    full_records = []
    for ev in evidence_list:
        ev_id = ev["id"]
        r = session.get(f"{base_url}/evidence/api/v1/evidence-by-id/{ev_id}")
        r.raise_for_status()
        full_ev = r.json()
        full_records.append(full_ev)

        slug    = full_ev.get("predicate_slug", "?")
        subject = full_ev.get("subject", {}).get("name", "?")
        verified = full_ev.get("verified", False)
        provider = full_ev.get("provider_id", "?")

        if verified:
            ok(f"[{slug}] verified", f"subject={subject}, provider={provider}")
        else:
            fail(f"[{slug}] NOT verified", f"subject={subject}, provider={provider}")
        info(f"  ID",  ev_id)
        info(f"  URI", full_ev.get("uri", "?")[:90])

    return full_records


# ── Final report ───────────────────────────────────────────────────────────────

def final_report(
    image_name, image_tag, cluster_name,
    image_digest,
    digest_aql_match, digest_storage_match, digest_in_build,
    git_commit, git_branch, git_message,
    build_url, build_number,
    evidence_records,
    risks, vulns,
):
    print(f"\n{'═' * WIDTH}")
    print(f"  COMPLIANCE REPORT")
    print(f"{'═' * WIDTH}")
    print(f"  Image:    {image_name}:{image_tag}")
    print(f"  Cluster:  {cluster_name}")
    print(f"  Digest:   sha256:{image_digest}")
    print(f"{'─' * WIDTH}")
    print(f"  Chain of Custody Checks")
    print(f"{'─' * WIDTH}")

    checks = []

    def check(label, passed, detail=""):
        checks.append(passed)
        icon   = "✅" if passed else "❌"
        suffix = f"  ({detail})" if detail else ""
        print(f"  {icon}  {label}{suffix}")

    check(
        "Runtime digest matches Artifactory artifact",
        digest_aql_match and digest_storage_match,
        f"sha256:{image_digest[:16]}...",
    )
    check(
        "Artifact traceable to CI/CD build",
        build_number is not None,
        f"build #{build_number}",
    )
    check(
        "Image digest present in build artifacts",
        digest_in_build,
    )
    check(
        "Git commit available from buildInfo.vcs",
        bool(git_commit),
        git_commit or "NOT FOUND",
    )
    check(
        "Source branch is expected (main)",
        git_branch == "main",
        git_branch or "unknown",
    )

    evidence_verified = any(e.get("verified") for e in evidence_records)
    evidence_count    = len(evidence_records)
    check(
        "SLSA provenance evidence present and signature verified",
        evidence_verified,
        f"{evidence_count} record(s)",
    )

    all_passed = all(checks)

    print(f"{'─' * WIDTH}")
    if all_passed:
        print(f"  ✅  RESULT: COMPLIANT — full chain of custody validated")
    else:
        print(f"  ❌  RESULT: NON-COMPLIANT — one or more checks failed")

    if git_commit:
        print(f"{'─' * WIDTH}")
        print(f"  Source Reference")
        print(f"  Commit:   {git_commit}")
        print(f"  Branch:   {git_branch}")
        print(f"  Message:  {git_message}")
        print(f"  CI Run:   {build_url}")

    if evidence_records:
        print(f"{'─' * WIDTH}")
        print(f"  Evidence Attestations")
        for ev in evidence_records:
            icon = "✅" if ev.get("verified") else "❌"
            print(f"  {icon}  [{ev.get('predicate_slug')}]  {ev.get('predicate_type')}")
            print(f"       created={ev.get('created_at')}  provider={ev.get('provider_id')}")

    if risks:
        print(f"{'─' * WIDTH}")
        print(f"  ⚠️  Runtime Risks")
        for risk in risks:
            print(f"       • {risk}")
        critical_applicable = [
            v for v in vulns
            if v.get("severity") == "Critical" and v.get("applicability") == "applicable"
        ]
        if critical_applicable:
            print(f"  Critical Applicable CVEs ({len(critical_applicable)})")
            for v in critical_applicable:
                comp = v["components"][0]["id"] if v.get("components") else "unknown"
                print(f"       • {v['cve_id']} ({v.get('cvss_v3', '?')} CVSS3) — {comp}")

    print(f"{'═' * WIDTH}\n")
    return all_passed


# ── Entry point ────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="JFrog Runtime Compliance Validator — traces a running image to its git source",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--image",       default=DEFAULTS["image"],       help="Container image name to trace")
    parser.add_argument("--cluster",     default=DEFAULTS["cluster"],     help="Runtime cluster name")
    parser.add_argument("--build-name",  default=DEFAULTS["build_name"],  help="Artifactory build name")
    parser.add_argument("--project",     default=DEFAULTS["project_key"], help="Artifactory project key")
    parser.add_argument("--jf-url",      default=DEFAULTS["jf_url"],      help="JFrog Platform base URL")
    parser.add_argument("--token-file",  default=DEFAULTS["token_file"],  help="Path to access token file")
    args = parser.parse_args()

    print(f"\n{'═' * WIDTH}")
    print(f"  JFrog Runtime Compliance Validator")
    print(f"  Image: {args.image}  |  Cluster: {args.cluster}")
    print(f"  Platform: {args.jf_url}")
    print(f"{'═' * WIDTH}")

    token = load_token(args.token_file)

    session = requests.Session()
    session.headers.update({"Authorization": f"Bearer {token}"})

    try:
        # Step 1 — Enumerate clusters
        step1_list_clusters(session, args.jf_url, args.cluster)

        # Step 2 — Find running image
        image_digest, image_tag, repo_path, risks, vulns = step2_find_image(
            session, args.jf_url, args.cluster, args.image
        )

        # Step 3a — AQL: locate manifest in Artifactory
        repo_key, manifest_path, artifact_created_at, digest_aql_match = step3a_aql_manifest(
            session, args.jf_url, args.image, image_digest, repo_path
        )

        # Step 3b — Storage: verify checksums
        _, digest_storage_match = step3b_storage_checksums(
            session, args.jf_url, repo_key, manifest_path, image_digest
        )

        # Step 4a — List builds
        step4a_list_builds(session, args.jf_url, args.project, args.build_name)

        # Step 4b — Find matching build run
        build_number = step4b_find_build_run(
            session, args.jf_url, args.build_name, args.project, artifact_created_at
        )

        # Step 4c — Get full build info
        build_url, git_commit, git_branch, git_message, digest_in_build = step4c_get_build_info(
            session, args.jf_url, args.build_name, build_number, args.project, image_digest
        )

        # Step 5a — Search evidence
        evidence_list = step5a_search_evidence(
            session, args.jf_url, repo_key, args.image, image_tag
        )

        # Step 5b — Get evidence by ID
        evidence_records = step5b_get_evidence_by_id(session, args.jf_url, evidence_list)

    except requests.HTTPError as e:
        print(f"\n  HTTP ERROR: {e.response.status_code} — {e.request.url}")
        print(f"  Response: {e.response.text[:300]}")
        sys.exit(2)

    # Final report
    compliant = final_report(
        image_name=args.image,
        image_tag=image_tag,
        cluster_name=args.cluster,
        image_digest=image_digest,
        digest_aql_match=digest_aql_match,
        digest_storage_match=digest_storage_match,
        digest_in_build=digest_in_build,
        git_commit=git_commit,
        git_branch=git_branch,
        git_message=git_message,
        build_url=build_url,
        build_number=build_number,
        evidence_records=evidence_records,
        risks=risks,
        vulns=vulns,
    )

    sys.exit(0 if compliant else 1)


if __name__ == "__main__":
    main()
