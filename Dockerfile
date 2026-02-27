FROM node:20-alpine

WORKDIR /app

COPY app/package.json app/server.js ./

# Unique build ID - pass via --build-arg to ensure every build has a unique digest (busts cache)
# Tag with both :latest and :<BUILD_ID> so you know which build latest points to.
# Local: BUILD_TAG=$(openssl rand -hex 4 | cut -c1-7); docker build --build-arg BUILD_ID=$BUILD_TAG -t ...:latest -t ...:$BUILD_TAG .
# CI: passes BUILD_ID=IMAGE_TAG (run number or input), tags with both
ARG BUILD_ID
RUN echo "${BUILD_ID:-unknown}" > /app/build_id.txt

EXPOSE 3000

CMD ["node", "server.js"]
