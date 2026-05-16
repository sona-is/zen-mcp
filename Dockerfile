FROM node:20-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY server.mjs ./
COPY launch-zen.sh ./
COPY README.md ./

ENV ZEN_DEBUG_PORT=9222

ENTRYPOINT ["node", "server.mjs"]
