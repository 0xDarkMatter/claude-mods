<?php
$rows = (new \craft\db\Query())->from('{{%orders}}')->andWhere("reference = '$search'")->all();
$query->orderBy($this->request->getQueryParam('sort'));
