allow-insecure-host = ["pypi.example.com", "localhost:8080"]

[[index]]
name = "internal"
url = "http://pypi.example.com/simple"

[pip]
extra-index-url = [
  "https://pypi.org/simple",
  "http://mirror.example.com/simple",
]
