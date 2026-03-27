FROM node:20-slim

# Install system dependencies:
#   ca-certificates — TLS trust for Codex/OpenAI API calls
#   gosu            — privilege dropping in entrypoint
#   git/curl/gh     — repo checkout, push, and PR tooling for execution agents
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates gosu git curl gh && rm -rf /var/lib/apt/lists/*

# Create a non-root user (required: Claude CLI refuses --dangerously-skip-permissions as root)
RUN groupadd -r paperclip && useradd -r -g paperclip -m -d /home/paperclip -s /bin/bash paperclip

# Create the paperclip home directory (Railway volume mount point),
# the .codex subdirectory for Codex CLI auth token storage,
# and the logs directory for Codex serve output
RUN mkdir -p /paperclip/.codex /paperclip/logs && chown -R paperclip:paperclip /paperclip

WORKDIR /app

# Copy package files and install dependencies (includes @openai/codex)
COPY package.json ./
RUN npm install --omit=dev

# Make the codex binary available system-wide
RUN ln -sf /app/node_modules/.bin/codex /usr/local/bin/codex

# Copy application code
COPY . .

# Give ownership of everything to the non-root user
RUN chown -R paperclip:paperclip /app /home/paperclip

# Copy and set up entrypoint (fixes volume mount ownership at runtime)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Railway injects PORT at runtime (default 3100)
ENV PORT=3100
EXPOSE 3100

# Point Codex CLI at the persistent volume so auth tokens survive container restarts.
ENV CODEX_HOME=/paperclip/.codex
ENV CODEX_CONFIG_DIR=/paperclip/.codex

# Entrypoint runs as root to fix volume permissions, then drops to paperclip user
ENTRYPOINT ["/entrypoint.sh"]
CMD ["npm", "start"]
