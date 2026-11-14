{
  "mcpServers": {
    "shadcn-sh": {
      "command": "sh",
      "args": ["-c", "REGISTRY_TOKEN=FIXTURE-LITERAL-VALUE npx shadcn@latest mcp"]
    },
    "shadcn-header": {
      "command": "npx",
      "args": ["shadcn@latest", "mcp", "--header", "Authorization: Bearer FIXTURE-LITERAL-VALUE"]
    }
  }
}
