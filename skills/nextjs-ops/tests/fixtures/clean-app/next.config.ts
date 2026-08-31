import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  cacheComponents: true,
  images: { remotePatterns: [{ protocol: 'https', hostname: 'cdn.example.com' }] },
}

export default nextConfig
