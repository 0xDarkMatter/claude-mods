engine-strict=true
strict-ssl=true
# strict-ssl=false
; registry=http://npm.example.com/
@fixture:registry=https://npm.example.com/
//npm.example.com/:_authToken=${NPM_TOKEN}
https-proxy=http://proxy.example.com:3128
@local:registry=http://localhost:4873/
