import { helper } from '../lib/utils';

// TODO: Fix authentication bug
export function main() {
  const result = helper('test');
  console.log(result);
}

export function authenticate(user: string, password: string): boolean {
  // FIXME: This is insecure
  return user === 'admin' && password === 'secret';
}
