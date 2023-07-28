// Run `make build-codecore` to build.

//import { createPlayground } from 'codekit:///livecodes';

import { createPlayground } from 'livecodes';

let playgroundPromise = new Promise((resolve, reject) => {
    createPlayground('#container', {
        //let playgroundPromise = createPlayground('#container', {
        appUrl: 'codekit:///livecodes/',
        lite: true,
        eager: true,
        params: {
        },
    })
    .then(playground => {
        resolve(playground)
    });
});
//    .then((playground) => {
//        console.log("hi3");
//        window.playground = playground;
//        exports.playground = window.playground;
//        resolve(playground)
//    });
//window.playgroundLoadedPromise = playgroundLoadedPromise;
//});

window.buildCode = async (markupLanguage, markupContent, styleLanguage, styleContent, scriptLanguage, scriptContent) => {
//    let buildCode = async () => {
        console.log("play?")
//        let playground = window.playground;
        console.log(playgroundPromise);
        let playground = await playgroundPromise;
        console.log("Hmm");
        console.log(playground);
        return "Hello world";
        
        await playground.load();
        await playground.setConfig({
            markup: { language: markupLanguage, content: markupContent },
            style: { language: styleLanguage, content: styleContent },
            script: { language: scriptLanguage, content: scriptContent },
        });
        let code = await playground.getCode();
        let resultPageHTML = code.result;
        return resultPageHTML;
//    };
    
//    await playgroundLoadedPromise;
//    return await buildCode(playground);
    
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
