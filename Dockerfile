FROM node:20-alpine

WORKDIR /app

COPY app/package.json app/server.js ./

# Unique build ID (7-digit hex) - ensures every build has a unique digest
RUN echo "$(openssl rand -hex 4 | cut -c1-7)" > /app/build_id.txt

EXPOSE 3000

CMD ["node", "server.js"]
