FROM node:24-alpine
RUN npm install --location=global pm2
WORKDIR /app
