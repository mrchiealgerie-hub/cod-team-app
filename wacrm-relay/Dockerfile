FROM node:20-slim

WORKDIR /app

# Install deps first for layer caching
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

# Copy source
COPY *.js ./

# Persistent volume for Baileys auth state (mounted by Railway/Render/Fly)
RUN mkdir -p /data/auth_info_baileys
ENV AUTH_DIR=/data/auth_info_baileys

EXPOSE 3000

CMD ["node", "server.js"]
