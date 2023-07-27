//import { createPlayground } from 'codekit:///livecodes';

import { createPlayground } from 'livecodes';

window.playground = null;
createPlayground('#container', {
    appUrl: 'codekit:///livecodes/',
    lite: true,
    eager: true,
    params: {
        
    },
}).then((playground) => {
    window.playground = playground;
    exports.playground = window.playground;
});

window.buildCode = async (id, markupLanguage, markupContent, styleLanguage, styleContent, scriptLanguage, scriptContent) => {
    await playground.load();
    await window.playground.setConfig({
        markup: {
            language: markupLanguage,
            content: markupContent,
        },
        style: {
            language: styleLanguage,
            content: styleContent,
        },
        script: {
            language: scriptLanguage,
            content: scriptContent,
        },
    });
    let code = await playground.getCode();
    let resultPageHTML = code.result;
    return "Hello world"
    return resultPageHTML;
}

window.runTests = () => {
    console.log("test")
}

//export let playground = window.playground;
//export let getCode = getCode
//export let runTests = runTests
