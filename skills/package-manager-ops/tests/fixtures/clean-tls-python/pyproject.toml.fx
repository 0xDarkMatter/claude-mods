[project]
name = "fixture-tool"
version = "0.1.0"

[project.urls]
Homepage = "http://example.com"

[tool.other]
allow-insecure-host = ["ignored.example.com"]
index-url = "http://pypi.example.com/simple"

[tool.uv]
index-url = "https://pypi.example.com/simple"
# allow-insecure-host = ["pypi.example.com"]
