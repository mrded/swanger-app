# Real-world specs

Unchanged copies of the Swagger Petstore, from
[swagger-api/swagger-petstore](https://github.com/swagger-api/swagger-petstore), licensed under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) (Copyright SmartBear Software):

| File | Source |
|---|---|
| `petstore-3.0.yaml` | [`src/main/resources/openapi.yaml`](https://github.com/swagger-api/swagger-petstore/blob/d57941e8fe959e508796b27469b1e8bba73392dc/src/main/resources/openapi.yaml) at `d57941e` (`master`) |
| `petstore-3.1.json` | [`src/main/webapp/code-first/openapi.json`](https://github.com/swagger-api/swagger-petstore/blob/c1b3c44cb0cae82a791742cdf6c822a8f5235a8f/src/main/webapp/code-first/openapi.json) at `c1b3c44` (`v31`) |

GitHub's and Stripe's specs (MIT) are too big to keep here. `scripts/fetch-real-world-specs.sh`
downloads them at pinned commits into `.build/real-world-specs/`.
