// The documented "push the await down" pattern: params is a Promise, passed
// down and awaited inside the boundary rather than at the top of the layout.
import { Suspense } from 'react'

export default function Layout({ children, params }: LayoutProps<'/shop/[slug]'>) {
  const slugPromise = params
  return (
    <div>
      <Sidebar />
      <Suspense fallback={<h1>Loading...</h1>}>
        {slugPromise.then(({ slug }) => <SlugHeading slug={slug} />)}
      </Suspense>
      {children}
    </div>
  )
}
