<?php
use craft\helpers\App;

class ReportsController extends \craft\web\Controller
{
    protected array|bool|int $allowAnonymous = ['public-summary'];

    public function actionExport(): \yii\web\Response
    {
        $this->requirePostRequest();
        $this->requirePermission('myModule-exportReports');

        $columns = ['title' => 'title', 'date' => 'postDate'];
        $sort = $columns[$this->request->getQueryParam('sort')] ?? 'postDate';
        $rows = (new \craft\db\Query())
            ->from('{{%orders}}')
            ->where(['userId' => $this->request->getRequiredBodyParam('userId')])
            ->orderBy([$sort => SORT_DESC])
            ->all();
        $prefs = json_decode($this->request->getBodyParam('prefs', '{}'), true, 32, JSON_THROW_ON_ERROR);

        return $this->asJson(['rows' => $rows, 'prefs' => $prefs]);
    }
}

return \craft\config\GeneralConfig::create()
    ->devMode(App::env('CRAFT_DEV_MODE') ?? false)
    ->securityKey(App::env('CRAFT_SECURITY_KEY'));
