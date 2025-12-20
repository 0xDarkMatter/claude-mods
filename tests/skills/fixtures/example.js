// Test fixture for structural-search tests

import React, { useState, useEffect } from 'react';
import lodash from 'lodash';

function App() {
  const [count, setCount] = useState(0);

  useEffect(() => {
    console.log('Component mounted');
  }, []);

  async function fetchData() {
    const response = await fetch('/api/data');
    return response.json();
  }

  const handleClick = () => {
    console.log('Button clicked');
    setCount(count + 1);
  };

  return (
    <div>
      <h1>Count: {count}</h1>
      <button onClick={handleClick}>Increment</button>
    </div>
  );
}

export default App;
