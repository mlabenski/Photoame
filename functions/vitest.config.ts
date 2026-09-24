import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    testTimeout: 20000,
    hookTimeout: 20000,
    // Emulator-backed tests share one Firestore; run files serially to keep
    // seeded data isolated per file.
    fileParallelism: false,
  },
});
