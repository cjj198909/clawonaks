FROM node:22-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg && \
    # kubectl
    curl -fsSL "https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl && \
    # az CLI
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json server.js index.html ./
RUN npm install --omit=dev

USER 1000
EXPOSE 3000
CMD ["node", "server.js"]
