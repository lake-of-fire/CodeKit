// Run `make build-codecore` to build.

//import { createPlayground } from 'codekit:///livecodes';

//import { createPlayground } from 'livecodes';

//let playgroundLoadedPromise = new Promise((resolve, reject) => {
//    return createPlayground('#container', {
let playgroundLoadedPromise = livecodes.createPlayground('#container', {
    appUrl: 'codekit:///livecodes/',
    lite: true,
    eager: true,
    params: {
        
    },
})
    .catch(error => {
        console.log("hi error");
        console.log(error)
    })
    .then((playground) => {
        console.log("hi3");
        window.playground = playground;
//        exports.playground = window.playground;
//        resolve(playground)
    });
window.playgroundLoadedPromise = playgroundLoadedPromise;
//});

window.buildCode = async (markupLanguage, markupContent, styleLanguage, styleContent, scriptLanguage, scriptContent) => {
        console.log("hi1");
    let buildCode = async () => {
        console.log("hi2");
        let playground = window.playground;
        await playground.load();
        await playground.setConfig({
            markup: { language: markupLanguage, content: markupContent },
            style: { language: styleLanguage, content: styleContent },
            script: { language: scriptLanguage, content: scriptContent },
        });
        let code = await playground.getCode();
        let resultPageHTML = code.result;
        return "Hello world";
        return resultPageHTML;
    };
    
    await playgroundLoadedPromise;
    return await buildCode(playground);
    
//    return await playgroundLoadedPromise.then((playground) => {
//        (async () => {
//            await buildCode(playground);
//        })();
//    });
};

window.runTests = () => {
    console.log("test")
};

//export let playground = window.playground;
//export let getCode = getCode
//export let runTests = runTests
