[project]
name = "fixture-tool"
version = "0.1.0"
urls = { Homepage = "http://example.com" }

[tool.uv]
allow-insecure-host = [
  "pypi.example.com",
]
index-url = "http://pypi.example.com/simple"  # internal mirror

[tool.other]
allow-insecure-host = ["ignored.example.com"]
