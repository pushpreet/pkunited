<?php
/**
 * APP_PRELOAD entry point — registers pre-auth middleware before the app boots.
 */

$app = require_once __DIR__ . '/bootstrap/app.php';

$app->booting(function ($app) {
    $kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);

    if ($kernel && method_exists($kernel, 'pushMiddleware')) {
        $middleware = require __DIR__ . '/pre-auth-middleware.php';
        $kernel->pushMiddleware($middleware);
    }
});
