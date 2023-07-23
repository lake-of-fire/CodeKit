import { nodeResolve } from "@rollup/plugin-node-resolve";
import commonjs from '@rollup/plugin-commonjs';
import { terser } from "@wwa/rollup-plugin-terser";

export default {
    input: "./codecore.js",
    output: {
        file: "./build/codecore.bundle.js",
        format: "iife",
        extend: true,
        name: "CodeCore",
        //exports: "named",
        exports: "none",
        externalLiveBindings: false,
        globals: {
            livecodes: 'livecodes',
        },
        plugins: [
            terser(),
        ],
    },
    external: [
        'livecodes',
    ],
    plugins: [
        nodeResolve({
            browser: true,
            ignoreGlobal: false,
//            include: ['node_modules/**'],
            moduleDirectories: ['node_modules'],
            extensions: ['.ts', '.tsx', '.mjs', '.js', '.json'],
//            exportConditions: ['node'],
            preferBuiltins: false,
//        rootDir: process.cwd()
        }),
//        commonjs(),
    ],
};
