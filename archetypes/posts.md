---
title: "{{ replace (replaceRE `^[0-9]{4}-[0-9]{2}-[0-9]{2}_` "" .Name) "-" " " | title }}"
date: {{ time (print (index (findRE `^[0-9]{4}-[0-9]{2}-[0-9]{2}` .Name) 0) "T00:00:00+00:00") }}
draft: false
type: "post"
featured: " "
tags: ["London",]
---

Start your story here.

{{< responsive-img src="image.jpg" alt="Description" >}}
