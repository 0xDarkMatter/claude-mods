// FIXTURE (nextjs-ops tests) - deliberately wrong. Not a template; see
// assets/next.config.template.ts for the correct starter.
import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  cacheComponents: true,
  images: {
    domains: ['images.example.com'],
  },
}

export default nextConfig
