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

window.buildCode = () => {
    console.log("build")
}

window.runTests = () => {
    console.log("test")
}

//export let playground = window.playground;
//export let getCode = getCode
//export let runTests = runTests
