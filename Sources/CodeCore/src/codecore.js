import { createPlayground } from 'livecodes';

window.playground = null;

createPlayground('#container', {
    lite: true,
    eager: true,
    params: {
        
    },
}).then((playground) => {
    window.playground = playground;
    exports.playground = window.playground;
});

let buildCode = () => {
    
}

let runTests = () => {
    
}

export let playground = window.playground;
export let getCode = getCode
export let runTests = runTests
