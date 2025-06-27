---
title: "{{ replace (replaceRE `^[0-9]{4}-[0-9]{2}-[0-9]{2}_` "" .Name) "-" " " | title }}"
date: {{ .Date }}
draft: false
url: "/{{ .Name | urlize }}"
featured: " "
---

Start your story here.

{{< responsive-img src="image.jpg" alt="Description" >}}
