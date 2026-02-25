FROM node:20-alpine

WORKDIR /app

COPY app/package.json app/server.js ./

EXPOSE 3000

CMD ["node", "server.js"]
