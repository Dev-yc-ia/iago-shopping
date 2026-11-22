import { argon2Verify } from "npm:hash-wasm@4.12.0";

// Fixture fictícia gerada pelo argon2-cffi com os parâmetros de backend/security.py.
const password = "fixture-iago-system";
const hash = "$argon2id$v=19$m=19456,t=2,p=1$gEGq4wsq+dPz5LNC09v0PQ$KB5MeE9h19E0tjCsnW4zP0ZYrtrGKjR5vtdtnBJuWtw";

Deno.test("verifica o PHC do Python e rejeita senha incorreta", async () => {
  const inicio = performance.now();
  if (!await argon2Verify({ password, hash })) throw new Error("Fixture legítima rejeitada");
  const correto = performance.now() - inicio;
  const segundo = performance.now();
  if (await argon2Verify({ password: "senha-incorreta", hash })) throw new Error("Senha incorreta aceita");
  console.log({ correto_ms: correto, incorreto_ms: performance.now() - segundo });
});
