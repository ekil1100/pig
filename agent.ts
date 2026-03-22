const systemPrompt = `Your name is Pig, a coding assistant. You have access to tools for working with code and the filesystem under ${Bun.cwd}. Use tools proactively when they would help. For example, inspect the project before asking the user for file paths. Prefer taking action over asking unnecessary questions.`;

async function loadEnv() {
  const envFile = Bun.file(".env");
  if (!(await envFile.exists())) return;

  const env = await envFile.text();
  for (const rawLine of env.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    const [key, ...vals] = line.split("=");
    if (!key?.trim() || vals.length === 0) continue;

    Bun.env[key.trim()] = vals.join("=").trim();
  }
}

async function chat(ctx: []) {
  const apiKey = Bun.env.GEMINI_API_KEY;
  if (!apiKey) {
    throw new Error("Missing GEMINI_API_KEY in .env file");
  }

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        systemInstruction: {
          parts: [{ text: systemPrompt }],
        },
        contents: ctx,
        tools: [
          {
            functionDeclarations: [
              {
                name: "list_files",
                description: "List files and directories at the given path",
                parameters: {
                  type: "object",
                  properties: {
                    directory: {
                      type: "string",
                      description: "Directory path to list",
                    },
                  },
                  required: ["directory"],
                },
              },
            ],
          },
        ],
        generationConfig: { thinkingConfig: { thinkingBudget: 0 } },
      }),
    },
  );

  if (!response.ok) {
    throw new Error(
      `Gemini API error ${response.status}: ${await response.text()}`,
    );
  }

  const json = await response.json();
  const res = json?.candidates?.[0]?.content;
  ctx.push(res);
  if (res?.parts) {
    for (let part of res.parts) {
      if (part.functionCall) {
        const functionCall = part.functionCall;
        const name = functionCall.name;
        const args = functionCall.args;
        return `${name} ${JSON.stringify(args)}`;
      }
    }
  }
  return res?.parts?.[0]?.text;
}

async function main() {
  await loadEnv();

  if (!Bun.env.GEMINI_API_KEY) {
    console.error("Missing GEMINI_API_KEY in .env file");
    return;
  }

  const ctx = [];

  while (true) {
    const input = prompt(">");
    if (input === null) break;

    const trimmed = input.trim();
    if (trimmed === "exit" || trimmed === "quit") break;
    if (!trimmed) continue;

    ctx.push({ role: "user", parts: [{ text: trimmed }] });

    try {
      const output = await chat(ctx);
      console.log(output);
    } catch (error) {
      console.error(error instanceof Error ? error.message : String(error));
    }
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
});
