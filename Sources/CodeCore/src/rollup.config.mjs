import { nodeResolve } from "@rollup/plugin-node-resolve";
import { typescript } from "@rollup/plugin-typescript";
import { terser } from "@wwa/rollup-plugin-terser";

export default {
    input: "./codecore.js",
    output: {
        file: "./build/codecore.bundle.js",
        format: "iife",
        extend: true,
        name: "CodeCore",
        exports: "named",
        globals: {
            livecodes: 'livecodes',
        },
        plugins: [
            terser(),
            typescript(),
            nodeResolve(),
        ],
    },
    external: [
        //'livecodes',
    ],
    plugins: [nodeResolve()],
};
