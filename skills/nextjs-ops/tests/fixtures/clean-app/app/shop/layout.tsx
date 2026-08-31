// A server layout that renders a client leaf - the correct shape. The route file
// itself must NOT carry 'use client'.
import { Panel } from '../ui/panel'

export default function ShopLayout({ children }: { children: React.ReactNode }) {
  return <section><Panel />{children}</section>
}
