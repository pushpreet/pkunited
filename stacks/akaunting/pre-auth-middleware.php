<?php
/**
 * Pre-auth middleware for Akaunting.
 *
 * Reads Authelia headers (set by Caddy forward_auth) and auto-creates/logs in
 * the Akaunting user. If no Remote-User header is present (e.g., API calls,
 * initial setup, or break-glass mode), passes through to normal auth.
 */

use Illuminate\Support\Facades\Auth;
use Akaunting\Users\Models\User;
use Illuminate\Support\Str;

return function ($request, $next) {
    $uid = $request->header('Remote-User');

    if (!$uid) {
        return $next($request);
    }

    $email = $request->header('Remote-Email', $uid . '@pushprh.com');
    $name  = $request->header('Remote-Name', $uid);

    $user = User::where('email', $email)->first();

    if (!$user) {
        $user = User::create([
            'user_key'          => $uid,
            'email'             => $email,
            'name'              => $name,
            'password'          => bcrypt(Str::random(40)),
            'login_attempts'    => 0,
            'login_strict'      => 0,
            'email_verified_at' => now(),
        ]);

        $groups = array_filter(array_map('trim', explode(',', $request->header('Remote-Groups', ''))));
        if (in_array('homelab_admins', $groups)) {
            $user->addRole(1); // admin role
        }
    }

    Auth::login($user, true);

    return $next($request);
};
