FROM node:20-alpine

WORKDIR /app

COPY package.json server.js ./

# Unique value - pass via --build-arg to ensure every build has a unique digest (busts cache)
# Tag with both :latest and :<UNIQUE_VALUE> so you know which build latest points to.
# Local: UNIQUE=$(openssl rand -hex 4 | cut -c1-7); docker build --build-arg UNIQUE_VALUE=$UNIQUE -t ...:latest -t ...:$UNIQUE .
# CI: generates random hex, passes UNIQUE_VALUE, tags with both
ARG UNIQUE_VALUE
RUN echo "${UNIQUE_VALUE:-unknown}" > /app/build_id.txt

EXPOSE 3000

CMD ["node", "server.js"]
