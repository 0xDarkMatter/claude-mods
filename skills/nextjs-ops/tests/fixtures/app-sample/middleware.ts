// FIXTURE bait: the file convention itself is the finding (deprecated in 16).
import { NextResponse } from 'next/server'

export function middleware() {
  return NextResponse.next()
}
