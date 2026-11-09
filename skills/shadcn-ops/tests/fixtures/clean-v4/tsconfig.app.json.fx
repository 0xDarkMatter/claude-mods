{
  "compilerOptions": {
    "target": "es2023",
    "jsx": "react-jsx",
    /* Bundler mode: comments and the trailing comma below are legal tsconfig (JSONC) */
    "moduleResolution": "bundler",
    // shadcn's Vite guide adds the same paths here and in tsconfig.json
    "paths": {
      "@/*": ["./src/*"],
    },
  },
  "include": ["src"]
}
