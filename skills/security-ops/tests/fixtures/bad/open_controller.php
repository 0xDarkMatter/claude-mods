<?php
class ReportsController extends \craft\web\Controller
{
    protected array|bool|int $allowAnonymous = true;

    public function beforeAction($action): bool
    {
        $this->enableCsrfValidation = false;
        return parent::beforeAction($action);
    }
}
