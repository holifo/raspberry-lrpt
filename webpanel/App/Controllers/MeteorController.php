<?php

# /meteor was the Sat info tab until v1.36.0; it is now part of About. Old links and bookmarks
# land there (the browser keeps any #fragment, so /meteor#iss still jumps to the ISS part).

namespace App\Controllers;

class MeteorController extends \Lib\Controller {
  public function indexAction($args) {
    header('Location: /about', true, 301);
    exit;
  }
}

?>
