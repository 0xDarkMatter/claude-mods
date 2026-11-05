<?php
$result = eval($formula);
$listing = shell_exec('ls ' . $dir);
$html = Craft::$app->getView()->renderString($this->request->getBodyParam('message'));
$hash = md5($password);
