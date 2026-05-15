FROM node:20-bullseye

SHELL ["/bin/bash", "-c"]

# Install build dependencies
RUN apt-get update \
    && apt-get install -y python3 build-essential \
    && apt-get -y autoclean

# Install global tools
RUN npm install -g pm2@5

RUN groupadd -r trinket && \
    useradd -r -g trinket -m -c "trinket user" trinket

RUN mkdir -p /usr/local/node/trinket && chown trinket:trinket /usr/local/node/trinket

USER trinket

WORKDIR /usr/local/node/trinket

# Install dependencies first — cached unless package.json changes
COPY --chown=trinket:trinket package.json package-lock.json ./
RUN npm install --legacy-peer-deps

# Download frontend components — cached unless the release URL changes
RUN curl -L --silent -o ./public-components.tgz \
    https://github.com/trinketapp/trinket-oss/releases/download/v1.0.0/public-components.tgz \
    && tar xzf public-components.tgz \
    && rm public-components.tgz

# Download Ace editor mode/theme files missing from the release tarball
RUN curl -L --silent -o ./public/components/src-min-noconflict/mode-markdown.js \
    https://cdn.jsdelivr.net/npm/ace-builds@1.2.6/src-min-noconflict/mode-markdown.js \
    && curl -L --silent -o ./public/components/src-min-noconflict/theme-github.js \
    https://cdn.jsdelivr.net/npm/ace-builds@1.2.6/src-min-noconflict/theme-github.js

# Copy source last so code changes don't bust the layers above
COPY --chown=trinket:trinket . .

# Generate CSS assets served from public/css
RUN npm run build:css

ARG COMMIT_ID
ARG NODE_ENV
ENV NODE_ENV=$NODE_ENV

EXPOSE 3000

CMD ["pm2-docker", "start", "app.js"]
