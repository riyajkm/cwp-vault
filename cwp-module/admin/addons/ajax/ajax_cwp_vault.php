<?php
if(!isset($include_path)){echo "invalid access";exit();}
// AJAX entry for CWP Vault: index.php?module=cwp_vault&acc=<action>. All logic lives in the shared lib.
require_once dirname(__DIR__, 2) . '/modules/cwp_vault/lib.php';
vault_dispatch(is_string($_GET['acc'] ?? null) ? $_GET['acc'] : '');
