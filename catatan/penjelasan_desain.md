![Desain Infra](Infra.jpg)

### Temuan-temuan
- Dengan menggunakan image wordpress:phpXX maka diperlukan setup wordpress page agar healthcheck tidak error. Hal ini disebabkan karena wordpress melakukan redirect ke installation page sedangkan healthcheck mengarah pada root website / 