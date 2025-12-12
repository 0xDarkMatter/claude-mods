// Utility functions
export function helper(input: string): string {
  return input.toUpperCase();
}

// TODO: Add error handling
export function parseConfig(json: string): object {
  return JSON.parse(json);
}
