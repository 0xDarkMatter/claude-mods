// FIXTURE negative control: correct on every rule. Must stay finding-free.
import { cookies } from 'next/headers'
import { Suspense } from 'react'

async function Greeting() {
  const store = await cookies()
  return <p>{store.get('theme')?.value ?? 'light'}</p>
}

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  return (
    <>
      <h1>{id}</h1>
      <Suspense fallback={<p>Loading...</p>}>
        <Greeting />
      </Suspense>
    </>
  )
}
