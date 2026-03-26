import { readdir } from "fs/promises";

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

function call(name: string) {
  switch (name) {
    case "list_files":
      return async (args: { directory: string }) => {
        try {
          const files = await readdir(args.directory);
          const filesStr = files.join("\n");
          return filesStr;
        } catch (err) {
          if (!(err instanceof Error)) return "unknow error";
          return err.message;
        }
      };
    case "read_file":
      return async (args: { path: string }) => {
        try {
          const file = Bun.file(args.path);
          if (!(await file.exists())) return "file not found";
          return await file.text();
        } catch (err) {
          if (!(err instanceof Error)) return "unknow error";
          return err.message;
        }
      };
    case "run_bash":
      return async (args: { command: string }) => {
        try {
          const { stdout, stderr, exitCode } = Bun.spawnSync(
            ["bash", "-lc", args.command],
            { timeout: 30000 },
          );
          if (exitCode != 0)
            return exitCode + ": " + stdout.toString() + stderr.toString();
          return stdout.toString() + stderr.toString();
        } catch (err) {
          if (!(err instanceof Error)) return "unknow error";
          return err.message;
        }
      };
    case "edit_file":
      return async (args: {
        path: string;
        old_string: string;
        new_string: string;
      }) => {
        try {
          const file = Bun.file(args.path);
          if (args.old_string === "") {
            if (!(await file.exists())) {
              await file.write(args.new_string);
              return `create file: ${args.path}`;
            }
            const writer = file.writer();
            await writer.write(args.new_string);
            await writer.end();
            return `append to file: ${args.path}`;
          }
          if (!(await file.exists())) {
            return `error: file not found`;
          }
          const content = await file.text();
          const splits = content.split(args.old_string);
          if (splits.length === 1) {
            return `error: old string is not found`;
          } else if (splits.length === 2) {
            await file.write(splits.join(args.new_string));
            return `update file: ${args.path}`;
          } else {
            return `error: old sring appears multiple times`;
          }
        } catch (err) {
          if (!(err instanceof Error)) return "unknow error";
          return err.message;
        }
      };
    default:
      return async () => "function not found";
  }
}

async function chat(ctx: []) {
  const apiKey = Bun.env.GEMINI_API_KEY;
  const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`;
  const body = {
    systemInstruction: {
      parts: [{ text: systemPrompt }],
    },
    contents: ctx,
    tools: [
      {
        functionDeclarations: [
          {
            name: "list_files",
            description: "list files and directories at the given path",
            parameters: {
              type: "object",
              properties: {
                directory: {
                  type: "string",
                  description: "directory path to list",
                },
              },
              required: ["directory"],
            },
          },
          {
            name: "read_file",
            description: "read the contents of a file at the given path",
            parameters: {
              type: "object",
              properties: {
                path: {
                  type: "string",
                  description: "file path to read",
                },
              },
              required: ["path"],
            },
          },
          {
            name: "run_bash",
            description: "execute a bash command and return its output",
            parameters: {
              type: "object",
              properties: {
                command: {
                  type: "string",
                  description: "command to run",
                },
              },
              required: ["command"],
            },
          },
          {
            name: "edit_file",
            description:
              "edit a file by replacing a specific string with new content. can alse create new file.",
            parameters: {
              type: "object",
              properties: {
                path: {
                  type: "string",
                  description: "file path to edit",
                },
                old_string: {
                  type: "string",
                  description: "old string",
                },
                new_string: {
                  type: "string",
                  description: "new string",
                },
              },
              required: ["path", "old_string", "new_string"],
            },
          },
        ],
      },
    ],
    generationConfig: { thinkingConfig: { thinkingBudget: 0 } },
  };

  while (true) {
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      throw new Error(
        `Gemini API error ${response.status}: ${await response.text()}`,
      );
    }

    const json = await response.json();
    const res: {
      parts?: { text?: string; functionCall?: { name: string; args: {} } }[];
    } = json.candidates[0].content;
    ctx.push(res);
    if (!res?.parts) return "no response";
    let hasFunctionCall = false;
    for (let part of res.parts) {
      if (!part.functionCall) continue;
      hasFunctionCall = true;
      const functionCall = part.functionCall;
      const name = functionCall.name;
      const args = functionCall.args;
      const result = await call(name)(args);
      ctx.push({
        role: "function",
        parts: [
          {
            functionResponse: {
              name,
              response: {
                name,
                content: result,
              },
            },
          },
        ],
      });
      console.log(`${name}${JSON.stringify(args)}\n\n${result}`);
    }
    if (hasFunctionCall) continue;
    return res?.parts?.[0]?.text;
  }
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
