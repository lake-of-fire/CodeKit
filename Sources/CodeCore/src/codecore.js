// Run `make build-codecore` to build.
import { createPlayground } from 'livecodes';

let playgroundPromise = createPlayground('#container', {
    appUrl: 'code://code/codekit/livecodes/',
    loading: 'eager',
    //lite: true, // <-- This breaks builds
    config: {
        editor: "codemirror",
        tabSize: 4,
        markup: { language: "html", content: "" },
        style: { language: "css", content: "" },
        script: { language: "js", content: "" },
        customSettings: {
            "defaultCDN": "skypack",
        },
    },
    //params: {
    //},
});

window.buildCode = async (markupLanguage, markupContent, styleLanguage, styleContent, scriptLanguage, scriptContent) => {
    let playground = await playgroundPromise;
    await playground.setConfig({
        markup: { language: markupLanguage, content: markupContent },
        style: { language: styleLanguage, content: styleContent },
        script: { language: scriptLanguage, content: scriptContent },
    });
    let code = await playground.getCode();
    let resultPageHTML = code.result;
    return resultPageHTML;
};

window.runTests = () => {
    console.log("test")
};

//export let playground = window.playground;
//export let getCode = getCode
//export let runTests = runTests
