'use client'
// A client leaf in a non-route file: correct, and must not fire
// client-component-route-file.
import { useState } from 'react'

export function Editor() {
  const [value, setValue] = useState('')
  return <textarea value={value} onChange={(e) => setValue(e.target.value)} />
}
