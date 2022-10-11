let lastRender = 0;
let canvas;
let ctx;
let fileInput;
let oldTimestamp;
let data;

window.onload = init;

function init() {
    fileInput = document.getElementById('file-input');
    fileInput.addEventListener('change', readFile, false);
    fileInput.style.display = "block";

    canvas = document.getElementById('canvas');
    ctx = canvas.getContext('2d');

    canvas.width = window.innerWidth;
    canvas.height = window.innerHeight;

    ctx.fillStyle = "#FF0000";
    ctx.strokeStyle = "#FF0000";
    ctx.lineWidth = 1;
    ctx.lineCap = "round";
    ctx.lineJoin = 0 ? "miter" : "round";

    ctx.lineCap = "square";
    ctx.lineWidth = 20;

    // Start the first frame request
    window.requestAnimationFrame(gameLoop);
}

function readFile(e) {
    let file = e.target.files[0];
    const reader = new FileReader();
    reader.onload = (event) => {
        data = JSON.parse(event.target.result);
        fileInput.style.display = "none";
    };
    reader.readAsText(file);
}

function draw() {

}

function gameLoop(timestamp) {
    // Calculate the number of seconds passed since the last frame
    let secondsPassed = (timestamp - oldTimestamp) / 1000;
    oldTimestamp = timestamp;

    // Calculate fps
    let fps = Math.round(1 / secondsPassed);

    // Draw number to the screen
    ctx.fillStyle = 'white';
    ctx.fillRect(0, 0, 200, 100);
    ctx.font = '25px Arial';
    ctx.fillStyle = 'black';
    ctx.fillText("FPS: " + fps, 10, 30);

    draw();

    lastRender = timestamp;
    window.requestAnimationFrame(gameLoop);
}
