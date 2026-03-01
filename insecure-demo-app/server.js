const express = require('express');
const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

const app = express();
const PORT = process.env.PORT || 3000;

// Unique value for build identification (same pattern as integrity-demo-app)
const BUILD_ID = (() => {
  try {
    return fs.readFileSync(path.join(__dirname, 'build_id.txt'), 'utf8').trim();
  } catch {
    return 'unknown';
  }
})();

app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString(), buildId: BUILD_ID });
});

app.get('/healthz', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Endpoint that uses glob CLI with -c option — CVE-2025-64756 exploitable path.
// When glob matches files with shell metacharacters in names, they are passed to shell with shell:true.
// See: https://github.com/isaacs/node-glob/security/advisories/GHSA-5j98-mcp5-4vw2
app.get('/files', (req, res) => {
  const filesDir = path.join(__dirname, 'files');
  try {
    // Use glob CLI -c: passes matched filenames to shell. Vulnerable to command injection
    // when filenames contain $(...), etc. The files/ directory has a malicious filename.
    const output = execSync('npx glob -c echo "*"', {
      cwd: filesDir,
      encoding: 'utf8',
      shell: true,
    });
    res.json({ files: output.trim().split(/\s+/).filter(Boolean) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/', (req, res) => {
  res.send(`Insecure Demo App (build: ${BUILD_ID})\n`);
});

app.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});
