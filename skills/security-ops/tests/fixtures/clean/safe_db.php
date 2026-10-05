<?php
$pdo->exec('SET NAMES utf8mb4');
$rows = Craft::$app->getDb()->createCommand('SELECT id FROM {{%orders}} WHERE userId = :uid', [':uid' => $userId])->queryAll();
$hash = password_hash($password, PASSWORD_DEFAULT);
$token = bin2hex(random_bytes(32));
