FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY server.js ./
COPY files/ ./files/

# Create file with shell metacharacters in filename — exploitable for CVE-2025-64756.
# When glob -c passes matches to shell, $(touch pwned) is evaluated. (No / in filename —
# / would be interpreted as path separator and break the touch during build.)
# Single quotes prevent expansion during this RUN.
RUN touch 'files/$(touch pwned)'

ARG UNIQUE_VALUE
RUN echo "${UNIQUE_VALUE:-unknown}" > /app/build_id.txt

EXPOSE 3000

CMD ["node", "server.js"]
