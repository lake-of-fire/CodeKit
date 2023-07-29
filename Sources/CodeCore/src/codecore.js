// Run `make build-codecore` to build.
//import { createPlayground } from 'codekit:///livecodes';
import { createPlayground } from 'livecodes';

let playgroundPromise = createPlayground('#container', {
    appUrl: 'codekit:///livecodes/',
    loading: 'eager',
    //template: 'react',
    lite: true,
    config: {
        markup: { language: "html", content: "" },
        style: { language: "css", content: "" },
        script: { language: "js", content: "" },
    },
    //params: {
    //},
});

window.buildCode = async (markupLanguage, markupContent, styleLanguage, styleContent, scriptLanguage, scriptContent) => {
        let playground = await playgroundPromise;
//        await playground.load();
    console.log("got playg")
//    await playground.run();
    //await playground.exec('showVersion');

    //console.log("fin showV")
    await playground.setConfig({
        markup: { language: markupLanguage, content: markupContent },
        style: { language: styleLanguage, content: styleContent },
        script: { language: scriptLanguage, content: scriptContent },
    });
    console.log("fin setconfig")
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
