# ned's secret finder (src/ned/core/secrets.nim): what the AI requests leave out — keys, tokens, private keys,
# passwords in URLs and assignments — and what they must keep (code that only names a password or a token), the
# placeholders put back into what the model writes, the files never sent, and the environment's secrets

import std/[json, strutils, unittest]
import ../../src/ned/core/secrets

# (each made-up key below is written in two parts, joined when the test runs, so that GitHub's secret
# scanning does not take it for a real one and refuse the push)

proc gone(text, secret: string): bool =
  ## the secret is not in the redacted text, and a placeholder is
  let r = redactSecrets(text)
  secret notin r and SecretMark in r

proc kept(text: string): bool = redactSecrets(text) == text

suite "secrets: found and replaced":
  test "keys and tokens by their shape":
    const cases = [
      "AKIA" & "IOSFODNN7EXAMPLE",                                              # AWS access key id
      "sk-" & "proj-Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7cDe0f",                 # OpenAI
      "sk-" & "ant-api03-q1W2e3R4t5Y6u7I8o9P0aSdFgHjKlZxCvBnMqWeRtYuIoP12345678-abcdefghijklmnopqrstuvwxyzABCDEFGH",
      "sk-" & "or-v1-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",   # OpenRouter
      "ghp" & "_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",                         # GitHub
      "github_" & "pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV",
      "glp" & "at-xYz12345678901234567",                                        # GitLab
      "xox" & "b-123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx",          # Slack
      "sk_" & "live_51H8abcdefGHIJKLmnopQRST",                                  # Stripe
      "AI" & "zaSyA1bC2dE3fG4hI5jK6lM7nO8pQ9rS0tU1v",                           # Google
      "np" & "m_abcdefghijklmnopqrstuvwxyz0123456789",                          # npm
      "hf" & "_abcdefghijklmnopqrstuvwxyzABCDEFGH",                             # Hugging Face
      "gs" & "k_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ0123456789AB",              # Groq
      "SG" & ".abcdefghijklmnopqrstuv.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",   # SendGrid
      "eyJ" & "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
      "123456789:A" & "AHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw0",                     # Telegram bot
      "AGE-" & "SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"]
    for k in cases:
      check gone("key = " & k, k)
      check gone("export TOKEN=" & k, k)
      check gone("text before " & k & " and after", k)
      check gone("{\"auth\": \"" & k & "\"}", k)

  test "private keys: the whole block":
    let pem = "-----BEGIN OPENSSH " & "PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\nAAAAMwAAAAtzc2gtZW\n" &
              "-----END OPENSSH PRIVATE KEY-----"
    let r = redactSecrets("before\n" & pem & "\nafter")
    check "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ" notin r
    check r.startsWith("before\n[REDACTED:private-key#1]\nafter")
    check gone("-----BEGIN RSA " & "PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n", "MIIEowIBAAKCAQEA")     # (cut off: to the end)
    # (a service account's JSON: the key with \n written out)
    check gone("{\"private_key\": \"-----BEGIN" & " PRIVATE KEY-----\\nMIIEvQIBADANBg\\n-----END PRIVATE KEY-----\\n\"}",
               "MIIEvQIBADANBg")
    check kept("-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----")
    check kept("-----BEGIN CERTIFICATE-----\nMIIDdzCCAl+gAwIBAgIEAgAAuTANBgkqhkiG\n-----END CERTIFICATE-----")

  test "passwords in connection strings and URLs":
    check gone("DATABASE_URL=postgres://app:s3cr3t-Pa55@db.internal:5432/app", "s3cr3t-Pa55")
    check redactSecrets("postgres://app:s3cr3t-Pa55@db/app") == "postgres://app:[REDACTED:password#1]@db/app"
    check gone("mongodb+srv://admin:hunter2@cluster0.example.net/test", "hunter2")
    check gone("https://user:tok3n@github.com/me/repo.git", "tok3n")
    check gone("Server=db;Database=app;User Id=sa;Password=Pa$$w0rd!;", "Pa$$w0rd!")
    check gone("DefaultEndpointsProtocol=https;AccountName=x;AccountKey=abc123def456ghi789==;EndpointSuffix=core",
               "abc123def456ghi789==")
    check gone("curl -H 'Authorization: Bearer abcdef0123456789abcdef' https://api", "abcdef0123456789abcdef")
    check gone("Authorization: Basic dXNlcjpwYXNzd29yZA==", "dXNlcjpwYXNzd29yZA==")
    check gone("https://hooks.slack.com/" & "services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX",
               "T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX")

  test ".env lines, settings, YAML, code literals":
    check gone("DB_PASSWORD=correcthorse", "correcthorse")
    check gone("SECRET_KEY_BASE=9f8e7d6c5b4a39281706f5e4d3c2b1a0", "9f8e7d6c5b4a39281706f5e4d3c2b1a0")
    check gone("export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
               "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    check gone("  password: hunter2", "hunter2")
    check gone("\"ai.apiKey\": \"0123456789abcdefABCDEF\"", "0123456789abcdefABCDEF")
    check gone("let password = \"correct horse battery staple\"", "correct horse battery staple")
    check gone("client_secret = 'Zx9-Qw8-Er7-Ty6-Ui5'", "Zx9-Qw8-Er7-Ty6-Ui5")
    check gone("mysql --password=Tr0ub4dor", "Tr0ub4dor")
    check gone("https://api.example.com/v1?api_key=4f9d2c7a1b3e5f6a&q=x", "4f9d2c7a1b3e5f6a")
    check gone("PGPASSWORD=s3cret psql -h db", "s3cret")
    # (only the value goes: the name and the quotes stay)
    check redactSecrets("DB_PASSWORD=\"correcthorse\"") == "DB_PASSWORD=\"[REDACTED:password#1]\""

suite "secrets: left as they are":
  test "code that names passwords and tokens":
    for s in ["proc login(user, password: string): bool =",
              "  password: string",
              "var token: Token",
              "tokenKind: TokenKind",
              "if password == \"\": return",
              "let password = readLine(stdin)",
              "let token = lexer.nextToken()",
              "API_KEY = os.environ[\"API_KEY\"]",
              "const apiKeyEnv = \"OPENAI_API_KEY\"",
              "passwordMinLength = 12",
              "secretName: \"db-credentials\"",
              "password = getpass.getpass()",
              "token = \"abc\"",
              "PWD=/home/me/src/ned",
              "DB_PASSWORD=${DB_PASSWORD}",
              "API_KEY=your-api-key-here",
              "password: \"<your password>\"",
              "SECRET=changeme",
              "raise newException(ValueError, \"the password is wrong\")",
              "echo \"password: \", pw",
              "# set ANTHROPIC_API_KEY in your shell"]:
      check kept(s)

  test "ordinary text, hashes, base64 that is not a key":
    for s in ["git commit 3f786850e387550fdab836ed7e6dc881de23001b",
              "sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
              "task-0123456789abcdefghij is done",
              "sk-learn is a Python library",
              "see https://github.com/foxoman/ned and http://localhost:8080/path",
              "ssh://git@github.com/foxoman/ned.git",
              "import std/[strutils, os]",
              "The primaryKey of the table is id",
              "Hello, world"]:
      check kept(s)

suite "secrets: the same placeholder, and back":
  test "one secret, one placeholder, across texts of a chat":
    var tab: SecretTable
    let k = "ghp" & "_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"
    let a = redactSecrets("first " & k, tab)
    let b = redactSecrets("again " & k & " and sk_" & "live_51H8abcdefGHIJKLmnopQRST", tab)
    check a == "first [REDACTED:github-token#1]"
    check b == "again [REDACTED:github-token#1] and [REDACTED:stripe-key#2]"
    check tab.items.len == 2
    check restoreSecrets(b, tab) == "again " & k & " and sk_" & "live_51H8abcdefGHIJKLmnopQRST"
    check redactSecrets(a, tab) == a                       # (a placeholder is not a secret)

  test "back into a tool call's JSON arguments, escaped":
    var tab: SecretTable
    let pem = "-----BEGIN EC " & "PRIVATE KEY-----\nMHcCAQEEIBkg\n-----END EC PRIVATE KEY-----"
    let r = redactSecrets("key file:\n" & pem, tab)
    check "MHcCAQEEIBkg" notin r
    let args = $(%*{"path": "k.pem", "content": "header\n[REDACTED:private-key#1]\n"})
    let back = parseJson(restoreSecretsJson(args, tab))
    check back["content"].getStr == "header\n" & pem & "\n"
    check restoreSecretsJson("{\"x\": 1}", tab) == "{\"x\": 1}"

  test "a whole request: every string in it":
    var tab: SecretTable
    let body = %*{"model": "m", "messages": [{"role": "user", "content": "use AKIA" & "IOSFODNN7EXAMPLE"},
                                             {"role": "tool", "content": "DB_PASSWORD=hunter22"}],
                  "image": "data:image/png;base64," & 'A'.repeat(200_000)}
    check redactSecretsJson(body, tab) == 2
    check "AKIA" & "IOSFODNN7EXAMPLE" notin $body and "hunter22" notin $body
    check body["image"].getStr.len > 200_000

  test "a big text: quick":
    var s = ""
    for i in 0 ..< 20000: s.add "let x" & $i & " = foo(bar, \"baz\") # some comment password: string\n"
    s.add "OPENAI_API_KEY=sk-" & "proj-Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7cDe0f\n"
    let r = redactSecrets(s)
    check r.len < s.len and "sk-proj-" notin r

suite "secrets: files never sent":
  test "by their names":
    for p in [".env", "app/.env", ".env.local", ".env.production", "prod.env", "certs/server.pem", "tls.key",
              "id_rsa", "/home/me/.ssh/id_ed25519", "store.p12", ".netrc", ".npmrc", "credentials.json",
              "terraform.tfstate", "secrets.yml", "client_secret_123.apps.json"]:
      check isSecretFile(p)
    for p in [".env.example", ".env.sample", ".env.template", "id_rsa.pub", "src/id_utils.nim", "main.nim",
              "README.md", "envelope.nim", "keys.nim", "config/settings.json", "venv/bin/python"]:
      check not isSecretFile(p)

  test "by the project's .gitignore":
    let pats = secretIgnorePatterns("# deps\nnode_modules/\n.venv/\n*.log\n.env*\n!.env.example\n" &
                                    "config/prod-secrets.yml\n*.pem\nkeys/private/\nbuild/\n")
    check pats == @[".env*", "config/prod-secrets.yml", "*.pem", "keys/private/"]
    check isSecretFile("/p/config/prod-secrets.yml", pats, "/p")
    check isSecretFile("/p/keys/private/a.txt", pats, "/p")
    check isSecretFile("/p/deep/x.pem", pats, "/p")
    check not isSecretFile("/p/config/dev.yml", pats, "/p")
    check not isSecretFile("/p/src/main.nim", pats, "/p")

  test "environment variables":
    for n in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "AWS_SECRET_ACCESS_KEY",
              "AWS_SESSION_TOKEN", "PGPASSWORD", "NPM_TOKEN", "SENTRY_DSN", "STRIPE_KEY", "DB_PWD"]:
      check secretEnvName(n)
    for n in ["PATH", "HOME", "TERM", "SSH_AUTH_SOCK", "LANG", "EDITOR", "NED_SOCKET", "KEYMAP", "PWD", "XDG_CONFIG_HOME",
              "MAX_THINKING_TOKENS", "GIT_TOKEN_FILE", "SSL_KEY_PATH"]:
      check not secretEnvName(n)
