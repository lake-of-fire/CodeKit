import { createPlayground } from 'livecodes';

window.playground = null;

createPlayground('#container', {
//    template: 'react'
    lite: true,
    eager: true,
    params: {
        
    },
}).then((playground) => {
    window.playground = playground;
    exports.playground = window.playground;
});

export let playground = window.playground;
