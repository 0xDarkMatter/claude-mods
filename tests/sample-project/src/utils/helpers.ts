// Utility functions for the application

export function formatDate(date: Date): string {
  return date.toISOString().split('T')[0];
}

export function debounce(fn: Function, delay: number) {
  let timeout: NodeJS.Timeout;
  return function(...args: any[]) {
    clearTimeout(timeout);
    timeout = setTimeout(() => fn(...args), delay);
  };
}

// TODO: Add throttle function
export function capitalize(str: string): string {
  return str.charAt(0).toUpperCase() + str.slice(1);
}
